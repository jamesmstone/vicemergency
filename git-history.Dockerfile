FROM python:alpine
RUN pip install git-history && apk add git
ENTRYPOINT ["git-history"]
